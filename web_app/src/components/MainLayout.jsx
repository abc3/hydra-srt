import { useState, useEffect } from 'react';
import PropTypes from 'prop-types';
import {
  MenuFoldOutlined,
  MenuUnfoldOutlined,
  DashboardOutlined,
  CompassOutlined,
  SettingOutlined,
  UserOutlined,
  DownOutlined,
  LogoutOutlined,
  LeftOutlined,
  RightOutlined,
  HomeOutlined,
  ApiOutlined,
  CodeOutlined,
} from '@ant-design/icons';
import { Button, Layout, Menu, theme, Grid, Avatar, Dropdown, Space, message, Breadcrumb } from 'antd';
import { useLocation, useNavigate } from 'react-router-dom';
import { logout, getUser } from '../utils/auth';
import { ROUTES } from '../utils/constants';
import React from 'react';

const { Header, Sider, Content } = Layout;
const { useBreakpoint } = Grid;

const MainLayout = ({ children }) => {
  const [collapsed, setCollapsed] = useState(false);
  const [user, setUser] = useState(null);
  const [breadcrumbItems, setBreadcrumbItems] = useState([]);
  const screens = useBreakpoint();
  const navigate = useNavigate();
  const location = useLocation();
  const {
    token: { colorBgContainer, borderRadiusLG },
  } = theme.useToken();

  // Expose setBreadcrumbItems to window object for child components
  useEffect(() => {
    window.setBreadcrumbItems = setBreadcrumbItems;
    window.breadcrumbSet = false;
    
    return () => {
      delete window.setBreadcrumbItems;
      delete window.breadcrumbSet;
    };
  }, []);

  useEffect(() => {
    setCollapsed(!screens.md);
  }, [screens.md]);

  useEffect(() => {
    // Get user from localStorage
    const userData = getUser();
    setUser(userData);
  }, []);

  // Reset breadcrumb items when location changes
  useEffect(() => {
    // Set default breadcrumb based on current path
    const path = location.pathname;
    
    // Reset breadcrumbs immediately when navigating to root
    if (path === ROUTES.DASHBOARD) {
      setBreadcrumbItems([
        {
          title: <HomeOutlined />,
        }
      ]);
      window.breadcrumbSet = false;
      return;
    }
    
    // For other paths, wait a bit to allow components to set their own breadcrumbs
    const timer = setTimeout(() => {
      // Check if we need to set default breadcrumbs for known routes
      if (!window.breadcrumbSet) {
        if (path.startsWith(ROUTES.ROUTES)) {
          if (path === ROUTES.ROUTES) {
            setBreadcrumbItems([
              {
                href: ROUTES.DASHBOARD,
                title: <HomeOutlined />,
              },
              {
                title: 'Routes',
              }
            ]);
          }
          // Don't set default breadcrumbs for child routes - let the components handle it
        } else if (path.startsWith(ROUTES.SETTINGS)) {
          setBreadcrumbItems([
            {
              href: ROUTES.DASHBOARD,
              title: <HomeOutlined />,
            },
            {
              title: 'Settings',
            }
          ]);
        } else if (path.startsWith(ROUTES.SYSTEM_PIPELINES)) {
          setBreadcrumbItems([
            {
              href: ROUTES.DASHBOARD,
              title: <HomeOutlined />,
            },
            {
              title: 'System Pipelines',
            }
          ]);
        } else if (path.startsWith(ROUTES.SYSTEM_NODES)) {
          setBreadcrumbItems([
            {
              href: ROUTES.DASHBOARD,
              title: <HomeOutlined />,
            },
            {
              title: 'System Nodes',
            }
          ]);
        }
      }
      
      // Reset the flag after setting breadcrumbs
      window.breadcrumbSet = false;
    }, 10);
    
    return () => clearTimeout(timer);
  }, [location.pathname]); // Remove breadcrumbItems from dependencies

  // Default breadcrumb with home icon - only run once on mount
  useEffect(() => {
    const defaultItems = [
      {
        title: <HomeOutlined />,
      }
    ];
    
    setBreadcrumbItems(defaultItems);
  }, []); // Empty dependency array - only run once on mount

  const handleLogout = () => {
    // Use the logout function from auth.js
    logout();
    message.success('Logged out successfully');
  };

  const dropdownItems = {
    items: [
      {
        key: '1',
        icon: <LogoutOutlined style={{ color: '#ff4d4f' }} />,
        label: <span style={{ color: '#ff4d4f' }}>Log out</span>,
        onClick: handleLogout,
      },
    ],
  };

  const menuItems = [
    {
      key: ROUTES.DASHBOARD,
      icon: <DashboardOutlined />,
      label: 'Dashboard',
    },
    {
      key: ROUTES.ROUTES,
      icon: <CompassOutlined />,
      label: 'Routes',
    },
    {
      key: ROUTES.SYSTEM_PIPELINES,
      icon: <CodeOutlined />,
      label: 'Pipelines',
    },
    {
      key: ROUTES.SYSTEM_NODES,
      icon: <ApiOutlined />,
      label: 'Nodes',
    },
    {
      key: ROUTES.SETTINGS,
      icon: <SettingOutlined />,
      label: 'Settings',
    },
  ];

  // Get the first letter of the username for the avatar
  const getAvatarText = () => {
    if (user) {
      return user.charAt(0).toUpperCase();
    }
    return 'U';
  };

  return (
    <Layout style={{ minHeight: '100vh' }}>
      <Sider
        trigger={null}
        collapsible
        collapsed={collapsed}
        breakpoint="md"
        collapsedWidth={screens.xs ? 0 : 80}
        onBreakpoint={(broken) => {
          setCollapsed(broken);
        }}
        style={{
          boxShadow: 'none',
          zIndex: 10,
          borderRight: '1px solid #1a1a1a',
          position: 'relative',
          display: 'flex',
          flexDirection: 'column',
          height: '100vh',
          paddingBottom: 0,
          overflow: 'hidden',
        }}
      >
        <div
          style={{
            height: 32,
            margin: '16px 16px 24px',
            display: 'flex',
            alignItems: 'center',
            color: 'white',
            fontWeight: 'bold',
            fontSize: '16px',
            justifyContent: 'space-between',
          }}
        >
          <div 
            style={{ 
              display: 'flex', 
              alignItems: 'center',
              cursor: 'pointer' 
            }}
            onClick={() => navigate('/')}
          >
            <img src="/logo2.webp" alt="HydraSRT Logo" style={{ width: '20px', height: '20px', marginRight: '8px' }} />
            {!collapsed && 'HydraSRT'}
          </div>
          {!screens.xs && (
            <Button
              type="text"
              icon={collapsed ? <MenuUnfoldOutlined style={{ color: 'rgba(255, 255, 255, 0.65)' }} /> : <MenuFoldOutlined style={{ color: 'rgba(255, 255, 255, 0.65)' }} />}
              onClick={() => setCollapsed(!collapsed)}
              style={{
                fontSize: '14px',
                padding: 0,
                width: 24,
                height: 24,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            />
          )}
        </div>
        <div style={{ 
          overflowY: 'auto', 
          flex: '1 1 auto',
          paddingBottom: 80,
        }}>
          <Menu
            theme="dark"
            mode="inline"
            selectedKeys={[
              // Keep parent route selected when on child routes
              location.pathname.startsWith('/routes/') ? ROUTES.ROUTES : 
              location.pathname.startsWith('/settings/') ? ROUTES.SETTINGS : 
              location.pathname.startsWith('/system/pipelines') ? ROUTES.SYSTEM_PIPELINES :
              location.pathname.startsWith('/system/nodes') ? ROUTES.SYSTEM_NODES :
              location.pathname
            ]}
            items={menuItems.map(item => ({
              ...item,
              icon: React.cloneElement(item.icon, {
                style: { fontSize: '16px' }
              })
            }))}
            onClick={({ key }) => {
              // Reset breadcrumb immediately for home navigation
              if (key === ROUTES.DASHBOARD) {
                setBreadcrumbItems([
                  {
                    title: <HomeOutlined />,
                  }
                ]);
              }
              navigate(key);
            }}
            style={{ 
              padding: '0 8px',
              background: 'transparent',
              border: 'none',
            }}
          />
        </div>
        
        {/* User profile at bottom of sidebar */}
        <div
          style={{
            borderTop: '1px solid #1a1a1a',
            width: '100%',
            position: 'absolute',
            bottom: 0,
            left: 0,
            right: 0,
            background: '#000000',
          }}
        >
          <Dropdown
            menu={dropdownItems}
            trigger={['click']}
            placement={collapsed ? 'rightTop' : 'top'}
          >
            <Button 
              type="text" 
              style={{ 
                width: '100%', 
                textAlign: 'left',
                padding: collapsed ? '16px 0' : '16px 12px',
                height: 'auto',
                borderRadius: 0,
                border: '1px solid #1a1a1a',
                borderLeft: 'none',
                borderRight: 'none',
                borderBottom: 'none',
                display: 'flex',
                alignItems: 'center',
              }}
            >
              <Space align="center" style={{ width: '100%', justifyContent: collapsed ? 'center' : 'flex-start' }}>
                <Avatar
                  size={32}
                  style={{
                    backgroundColor: '#4169e1', // Royal blue
                    color: '#fff',
                  }}
                >
                  {getAvatarText()}
                </Avatar>
                {!collapsed && (
                  <div style={{ 
                    display: 'flex', 
                    flexDirection: 'column', 
                    alignItems: 'flex-start',
                    marginLeft: 8,
                  }}>
                    <span style={{ 
                      color: 'rgba(255, 255, 255, 0.85)', 
                      lineHeight: '1.2',
                      fontSize: '14px',
                      fontWeight: '500',
                    }}>
                      {user || 'admin'}
                    </span>
                    <small style={{ 
                      color: 'rgba(255, 255, 255, 0.45)', 
                      fontSize: '12px',
                    }}>
                      View profile
                    </small>
                  </div>
                )}
              </Space>
            </Button>
          </Dropdown>
        </div>
      </Sider>
      <Layout style={{ 
        position: 'relative', 
        zIndex: 1,
        marginLeft: collapsed ? 0 : 0,
      }}>
        <div
          style={{
            padding: '0 16px',
            background: '#000000',
            top: 0,
            zIndex: 9,
            width: '100%',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            boxShadow: 'none',
            borderBottom: '1px solid #1a1a1a',
            height: 56,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', height: '100%' }}>
            {screens.xs && (
              <Button
                type="text"
                icon={collapsed ? <MenuUnfoldOutlined style={{ color: 'rgba(255, 255, 255, 0.65)' }} /> : <MenuFoldOutlined style={{ color: 'rgba(255, 255, 255, 0.65)' }} />}
                onClick={() => setCollapsed(!collapsed)}
                style={{
                  fontSize: '16px',
                  marginRight: '16px',
                }}
              />
            )}
            <Breadcrumb 
              items={breadcrumbItems}
              onClick={(e) => {
                const target = e.target.closest('a');
                if (target) {
                  e.preventDefault();
                  const href = target.getAttribute('href');
                  if (href) {
                    // Reset breadcrumb immediately for home navigation
                    if (href === ROUTES.DASHBOARD) {
                      setBreadcrumbItems([
                        {
                          title: <HomeOutlined />,
                        }
                      ]);
                    }
                    navigate(href);
                  }
                }
              }}
              style={{
                color: 'rgba(255, 255, 255, 0.65)',
              }}
            />
          </div>
          <div />
        </div>
        <Content
          style={{
            margin: screens.md ? '16px' : '8px',
            padding: screens.md ? 16 : 12,
            minHeight: 280,
            borderRadius: 4,
            overflow: 'auto',
            boxShadow: 'none',
            position: 'relative',
            zIndex: 1,
          }}
        >
          {children}
        </Content>
      </Layout>
    </Layout>
  );
};

MainLayout.propTypes = {
  children: PropTypes.node.isRequired,
};

export default MainLayout;
